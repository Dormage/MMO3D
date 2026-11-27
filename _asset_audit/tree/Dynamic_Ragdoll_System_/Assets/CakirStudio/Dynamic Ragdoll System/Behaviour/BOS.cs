using UnityEngine;

namespace DynamicRagdoll
{
    public class BOS : MonoBehaviour
    {
        public Transform LeftKnee;
        public Transform LeftFoot;
        public Transform LeftToe;
        public Transform RightKnee;
        public Transform RightFoot;
        public Transform RightToe;

        [HideInInspector]
        public FootDetect RightKneeDet;
        [HideInInspector]
        public FootDetect LeftKneeDet;
        [HideInInspector]
        public FootDetect RightFootDet;
        [HideInInspector]
        public FootDetect LeftFootDet;
        public Vector3 Bospoint => GetBospoint();
        public bool BosActive { get; private set; }
        public bool AllGrounded { get; private set; }

        private void Start()
        {
            RightKneeDet = RightKnee.GetComponent<FootDetect>();
            RightFootDet = RightFoot.GetComponent<FootDetect>();
            LeftKneeDet = LeftKnee.GetComponent<FootDetect>();
            LeftFootDet = LeftFoot.GetComponent<FootDetect>();

        }
        private void FixedUpdate()
        {
            FindBOS();
        }
        private void FindBOS()
        {

            if ((RightKneeDet.isGrounded || RightFootDet.isGrounded) && (LeftKneeDet.isGrounded || LeftFootDet.isGrounded))
            {
                BosActive = true;
                AllGrounded = true;
            }
            else if ((RightKneeDet.isGrounded || RightFootDet.isGrounded) && !(LeftKneeDet.isGrounded || LeftFootDet.isGrounded))
            {
                BosActive = true;
                AllGrounded = false;
            }
            else if (!(RightKneeDet.isGrounded || RightFootDet.isGrounded) && (LeftKneeDet.isGrounded || LeftFootDet.isGrounded))
            {
                BosActive = true;
                AllGrounded = false;
            }
            else
            {
                AllGrounded = false;
                BosActive = false;
            }

        }

        public Vector3 GetBospoint()
        {
            //Vector3 sum = RightFoot.position * 2f + LeftFoot.position * 2f + RightToe.position + LeftToe.position;
            //return sum / 6f;
            return (RightFoot.position+ LeftFoot.position) / 2f;
        }
    }

}
